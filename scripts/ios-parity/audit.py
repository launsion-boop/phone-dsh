#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""iOS × official DSH session-line parity scanner.

Static, dependency-free extractor for the session conversation line:

1. Resolve the official theme tokens (light/dark) from the shipped CSS.
2. Extract the official component metrics for the transcript / composer /
   header / plan / question / subagent surfaces.
3. Inventory official session surfaces: chat node kinds, toolview keys,
   conversation slots, session projections.
4. Inventory the current iOS equivalents from Swift sources.
5. Compare, and scan the 8 audit reports for coverage.

The output is intentionally a *report*, not a gate: it tells you where the
audit and the current iOS implementation still have holes. Run it after
updating the official pin or the iOS chat code.

Usage:
  python3 scripts/ios-parity/audit.py
  python3 scripts/ios-parity/audit.py --official /path/to/deepseek-harness
  python3 scripts/ios-parity/audit.py --out docs/receipts/ios-session-audit/parity

Exit code is 0 even when gaps are found; gaps are data, not a build failure.
"""

from __future__ import annotations

import argparse
import json
import math
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable

DEFAULT_OFFICIAL = Path(
    "~/Documents/Codex/2026-08-14/"
    "https-github-com-deepseek-ai-deepseek/deepseek-harness"
)

# ---------------------------------------------------------------------------
# CSS parsing
# ---------------------------------------------------------------------------

_COMMENT_RE = re.compile(r"/\*.*?\*/", re.S)
_WS_RE = re.compile(r"\s+")


def norm(value: str) -> str:
    return _WS_RE.sub(" ", value).strip()


def strip_comments(text: str) -> str:
    return _COMMENT_RE.sub("", text)


def parse_css_rules(text: str, media: str = "") -> list[tuple[str, str, str]]:
    """Return (selector, declaration-body, media/container context) rules."""
    text = strip_comments(text)
    rules: list[tuple[str, str, str]] = []
    buf: list[str] = []
    i = 0
    while i < len(text):
        ch = text[i]
        if ch == "{":
            selector = norm("".join(buf))
            depth = 1
            j = i + 1
            while j < len(text) and depth > 0:
                if text[j] == "{":
                    depth += 1
                elif text[j] == "}":
                    depth -= 1
                j += 1
            body = text[i + 1 : j - 1]
            if selector.startswith(("@media", "@container", "@supports")):
                rules.extend(parse_css_rules(body, (media + " " + selector).strip()))
            elif selector.startswith(("@keyframes", "@font-face", "@page")):
                pass
            elif selector:
                rules.append((selector, body, media))
            buf = []
            i = j
        elif ch == "}":
            buf = []
            i += 1
        else:
            buf.append(ch)
            i += 1
    return rules


def split_top_level(text: str, separator: str) -> list[str]:
    out: list[str] = []
    depth = 0
    quote: str | None = None
    start = 0
    for i, ch in enumerate(text):
        if quote is not None:
            if ch == quote and (i == 0 or text[i - 1] != "\\"):
                quote = None
        elif ch in "\"'":
            quote = ch
        elif ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth = max(0, depth - 1)
        elif ch == separator and depth == 0:
            out.append(text[start:i])
            start = i + 1
    out.append(text[start:])
    return out


def parse_declarations(body: str) -> list[tuple[str, str]]:
    decls: list[tuple[str, str]] = []
    for part in split_top_level(body, ";"):
        if ":" not in part:
            continue
        prop, value = part.split(":", 1)
        prop = norm(prop)
        value = norm(value)
        if not prop or not value or prop.startswith("@"):
            continue
        decls.append((prop, value))
    return decls


def _find_var_calls(value: str) -> list[tuple[int, int, str, str | None]]:
    """Locate var(...) calls and return (start, end, name, fallback)."""
    calls: list[tuple[int, int, str, str | None]] = []
    i = 0
    while True:
        start = value.find("var(", i)
        if start < 0:
            break
        depth = 0
        end = -1
        for j in range(start + 4, len(value)):
            if value[j] == "(":
                depth += 1
            elif value[j] == ")":
                if depth == 0:
                    end = j
                    break
                depth -= 1
        if end < 0:
            break
        inner = value[start + 4 : end]
        parts = split_top_level(inner, ",")
        name = parts[0].strip()
        fallback = ",".join(parts[1:]).strip() if len(parts) > 1 else None
        calls.append((start, end + 1, name, fallback))
        i = end + 1
    return calls


def _eval_simple_calc(inner: str) -> str | None:
    """Evaluate calc() when it is pure px arithmetic; otherwise return None."""
    if "%" in inner or "var(" in inner:
        return None
    expr = re.sub(r"(\d+(?:\.\d+)?)px", r"\1", inner)
    if not re.fullmatch(r"[\d+\-*/().\s]+", expr):
        return None
    try:
        value = eval(expr, {"__builtins__": {}}, {})  # noqa: S307 - sanitized arithmetic
    except Exception:
        return None
    if not math.isfinite(value):
        return None
    value = round(value, 2)
    return f"{value:g}px" if "px" in inner else f"{value:g}"


def _eval_calcs(value: str) -> str:
    out = value
    for _ in range(8):
        match = re.search(r"calc\(([^()]*)\)", out)
        if match is None:
            break
        result = _eval_simple_calc(match.group(1))
        if result is None:
            break
        out = out[: match.start()] + result + out[match.end() :]
    return out


def resolve_value(value: str, tokens: dict[str, str], depth: int = 0) -> str:
    if depth > 12:
        return value
    out = value
    for start, end, name, fallback in reversed(_find_var_calls(out)):
        replacement = tokens.get(name)
        if replacement is None:
            replacement = fallback if fallback is not None else f"var({name})"
        out = out[:start] + replacement + out[end:]
    out = _eval_calcs(out)
    if "var(" in out:
        return resolve_value(out, tokens, depth + 1)
    return out


def load_css_tokens(path: Path, light: dict[str, str], dark: dict[str, str]) -> None:
    if not path.is_file():
        return
    for selector, body, _media in parse_css_rules(path.read_text(encoding="utf-8")):
        is_dark = "data-ds-dark-theme" in selector or "dark" in selector.lower()
        target = dark if is_dark else light
        for prop, value in parse_declarations(body):
            if prop.startswith("--"):
                target[prop] = value


# ---------------------------------------------------------------------------
# Official component surfaces
# ---------------------------------------------------------------------------

SURFACES: list[dict] = [
    {
        "name": "assistant_body",
        "file": "packages/client/ui-chat/src/client/chat/AssistantMarkdown.module.css",
        "classes": ["root", "body"],
    },
    {
        "name": "user_bubble",
        "file": "packages/client/ui-chat/src/client/chat/MessageItem.module.css",
        "classes": ["userStack", "bubble", "referenceSummary"],
    },
    {
        "name": "tool_row",
        "file": "packages/client/ui-tool/src/client/tool/components/ToolRow.module.css",
        "classes": ["root", "title", "summary", "sep", "summarySuffix"],
    },
    {
        "name": "turn_process",
        "file": "packages/client/ui-chat/src/client/chat/TurnProcessNodeView.module.css",
        "classes": ["root", "label", "chevron"],
    },
    {
        "name": "chat_flow",
        "file": "packages/client/ui-chat/src/client/chat/ChatView.module.css",
        "classes": ["scroll", "column", "running", "runningContent", "runningDivider", "toBottom"],
    },
    {
        "name": "group_seat",
        "file": "packages/client/ui-chat/src/client/chat/ChatGroupSeat.module.css",
        "classes": ["header", "label", "body", "content"],
    },
    {
        "name": "todo_panel",
        "file": "packages/client/ui-conversation/src/client/skeleton/TodoPanel.module.css",
        "classes": ["root", "header", "title", "progress", "list", "item"],
    },
    {
        "name": "plan_chip",
        "file": "packages/client/ui-plan/src/client/PlanModeControl.module.css",
        "classes": ["chip"],
    },
    {
        "name": "plan_review",
        "file": "packages/client/ui-user-questions/src/client/PlanReviewPanel.module.css",
        "classes": ["card", "strip", "summary", "footer"],
    },
    {
        "name": "plan_card",
        "file": "packages/client/ui-plan/src/client/PlanPreview.module.css",
        "classes": ["card", "cards", "cardIcon", "cardDetails", "cardTitle", "cardDescription", "cardOpen"],
    },
    {
        "name": "question_composer",
        "file": "packages/client/ui-user-questions/src/client/QuestionComposer.module.css",
        "classes": ["card", "header", "title", "option", "footer", "body"],
    },
    {
        "name": "question_reply",
        "file": "packages/client/ui-user-questions/src/client/QuestionReplyView.module.css",
        "classes": ["row", "bubble", "actions"],
    },
    {
        "name": "turn_trigger",
        "file": "packages/client/ui-chat/src/client/chat/TurnTriggerNodeView.module.css",
        "classes": ["root", "header", "title", "body"],
    },
    {
        "name": "composer",
        "file": "packages/client/ui-conversation/src/client/skeleton/InputBar.module.css",
        "classes": ["card", "row", "input", "primary", "add", "select"],
    },
    {
        "name": "header",
        "file": "packages/client/ui-conversation/src/client/skeleton/ConversationRoot.module.css",
        "classes": ["header", "titleRow", "crumb", "crumbCurrent", "headerActions", "headerUtilities", "tabs", "tab", "tabActive"],
    },
    {
        "name": "turn_tail",
        "file": "packages/client/ui-chat/src/client/chat/TurnTailNodeView.module.css",
        "classes": ["root", "actions"],
    },
    {
        "name": "message_actions",
        "file": "packages/client/ui-chat/src/client/chat/MessageIconActions.module.css",
        "classes": ["actions", "action", "timeStart", "timeEnd"],
    },
    {
        "name": "stats_pills",
        "file": "packages/client/ui-chat/src/client/chat/StatsPills.module.css",
        "classes": ["anchor", "pill", "label"],
    },
    {
        "name": "queue_dock",
        "file": "packages/client/ui-conversation/src/client/queue/QueueDock.module.css",
        "classes": ["dock", "panel", "header", "row"],
    },
    {
        "name": "goal_bar",
        "file": "packages/client/ui-goal/src/client/GoalBar.module.css",
        "classes": ["root", "row"],
    },
    {
        "name": "approval_panel",
        "file": "packages/client/ui-approval/src/client/ApprovalPanel.module.css",
        "classes": ["root", "card", "strip", "actionRow"],
    },
    {
        "name": "subagent_menu",
        "file": "packages/client/ui-subagent/src/client/SubagentHeaderLineage.module.css",
        "classes": ["trigger", "switcherTrigger", "menu", "row"],
    },
    {
        "name": "code_card",
        "file": "packages/client/ui-primitives/src/CodeCard.module.css",
        "classes": ["root", "banner", "body"],
    },
]

DETAIL_FIELDS = {
    "font",
    "font-size",
    "font-weight",
    "line-height",
    "letter-spacing",
    "padding",
    "padding-top",
    "padding-right",
    "padding-bottom",
    "padding-left",
    "margin",
    "margin-top",
    "margin-right",
    "margin-bottom",
    "margin-left",
    "gap",
    "row-gap",
    "column-gap",
    "height",
    "min-height",
    "max-height",
    "width",
    "min-width",
    "max-width",
    "border",
    "border-radius",
    "border-bottom",
    "color",
    "background",
    "background-color",
    "box-shadow",
    "backdrop-filter",
    "transition",
    "opacity",
    "transform",
    "white-space",
    "text-overflow",
    "overflow",
}


def _class_regex(cls: str) -> re.Pattern:
    return re.compile(rf"(^|[\s,>+~])\.{re.escape(cls)}(?=$|[\s,{{:.#\[])")


def select_rules(rules: list[tuple[str, str, str]], cls: str) -> list[dict]:
    pattern = _class_regex(cls)
    matches: list[dict] = []
    for selector, body, media in rules:
        parts = [norm(part) for part in split_top_level(selector, ",")]
        for part in parts:
            if pattern.search(part):
                exact = part == f".{cls}"
                decls = {
                    prop: value
                    for prop, value in parse_declarations(body)
                    if prop in DETAIL_FIELDS
                }
                if decls:
                    matches.append(
                        {
                            "selector": part,
                            "media": media,
                            "exact": exact,
                            "declarations": decls,
                        }
                    )
                break
    return matches


def extract_components(official: Path, tokens_light: dict[str, str], tokens_dark: dict[str, str]) -> dict:
    result: dict[str, dict] = {}
    for surface in SURFACES:
        path = official / surface["file"]
        if not path.is_file():
            result[surface["name"]] = {"file": surface["file"], "missing": True}
            continue
        rules = parse_css_rules(path.read_text(encoding="utf-8"))
        classes: dict[str, dict] = {}
        for cls in surface["classes"]:
            matches = select_rules(rules, cls)
            if not matches:
                continue
            base = next(
                (m for m in matches if m["exact"] and not m["media"]),
                next((m for m in matches if not m["media"]), matches[0]),
            )
            classes[cls] = {
                "base": {
                    "selector": base["selector"],
                    "media": base["media"],
                    "declarations": {
                        prop: {
                            "raw": value,
                            "light": resolve_value(value, tokens_light),
                            "dark": resolve_value(value, tokens_dark),
                        }
                        for prop, value in base["declarations"].items()
                    },
                },
                "variants": [
                    {
                        "selector": m["selector"],
                        "media": m["media"],
                        "declarations": {
                            prop: {
                                "raw": value,
                                "light": resolve_value(value, tokens_light),
                                "dark": resolve_value(value, tokens_dark),
                            }
                            for prop, value in m["declarations"].items()
                        },
                    }
                    for m in matches
                    if m is not base
                ],
            }
        result[surface["name"]] = {"file": surface["file"], "classes": classes}
    return result


# ---------------------------------------------------------------------------
# Inventory
# ---------------------------------------------------------------------------

SOURCE_SUFFIXES = {".ts", ".tsx", ".js", ".jsx", ".css"}
SKIP_PARTS = {"node_modules", "lib", "tests", "test", "dist", "build"}


def iter_source(root: Path) -> Iterable[Path]:
    for path in root.rglob("*"):
        if not path.is_file() or path.suffix not in SOURCE_SUFFIXES:
            continue
        if any(part in SKIP_PARTS for part in path.parts):
            continue
        if ".d.ts" in path.name:
            continue
        yield path


def unique_sorted(values: Iterable[str]) -> list[str]:
    return sorted({value for value in values if value})


def extract_interface_keys(text: str, interface: str) -> list[str]:
    keys: list[str] = []
    for match in re.finditer(rf"interface\s+{re.escape(interface)}\s*\{{", text):
        start = match.end()
        depth = 1
        i = start
        while i < len(text) and depth > 0:
            if text[i] == "{":
                depth += 1
            elif text[i] == "}":
                depth -= 1
            i += 1
        body = text[start : i - 1]
        # Strip block comments and line comments, then read member keys.
        body = re.sub(r"/\*.*?\*/", "", body, flags=re.S)
        body = re.sub(r"//[^\n]*", "", body)
        for line in body.splitlines():
            key_match = re.match(r"\s*(?:'([^']+)'|([A-Za-z_$][\w$-]*))\??\s*[:(]", line)
            if key_match:
                keys.append(key_match.group(1) or key_match.group(2) or "")
    return unique_sorted(keys)


def extract_official_inventory(official: Path) -> dict:
    chat_nodes: dict[str, list[str]] = {}
    toolviews: dict[str, list[str]] = {}
    slots: dict[str, list[str]] = {}
    projections: set[str] = set()
    contributions: list[dict] = []

    for path in iter_source(official / "packages"):
        rel = str(path.relative_to(official))
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        for key in extract_interface_keys(text, "ChatNodeDataMap"):
            chat_nodes.setdefault(key, []).append(rel)
        for key in extract_interface_keys(text, "SessionProjectionMap"):
            projections.add(key)
        for key in extract_interface_keys(text, "SessionProjectionStateMap"):
            projections.add(key)

        for match in re.finditer(
            r"name:\s*'tool\.call\.toolview'\s*,\s*key:\s*'([^']+)'", text
        ):
            toolviews.setdefault(match.group(1), []).append(rel)
        for match in re.finditer(
            r"key:\s*'([^']+)'\s*,\s*name:\s*'tool\.call\.toolview'", text
        ):
            toolviews.setdefault(match.group(1), []).append(rel)
        # Function* registrations: yield ctx.slots.register({ name: ..., key: ... })
        for match in re.finditer(r"name:\s*'tool\.call\.toolview'", text):
            window = text[match.start() : match.start() + 400]
            key_match = re.search(r"key:\s*'([^']+)'", window)
            if key_match:
                toolviews.setdefault(key_match.group(1), []).append(rel)

        for match in re.finditer(
            r"\.register(?:Factory)?\(\s*\{[\s\S]{0,400}?name:\s*'(conversation\.[a-z0-9_.-]+)'",
            text,
        ):
            slot = match.group(1)
            slots.setdefault(slot, []).append(rel)
            window = text[match.start() : match.start() + 700]
            id_match = re.search(r"\bid:\s*'([^']+)'", window)
            key_match = re.search(r"\bkey:\s*'([^']+)'", window)
            label_match = re.search(r"\blabel:\s*'([^']+)'", window)
            contributions.append(
                {
                    "slot": slot,
                    "id": id_match.group(1) if id_match else "",
                    "key": key_match.group(1) if key_match else "",
                    "label": label_match.group(1) if label_match else "",
                    "file": rel,
                }
            )

    # Deduplicate contributions while preserving first-seen order.
    seen_contrib: set[tuple[str, str, str, str]] = set()
    unique_contrib: list[dict] = []
    for item in contributions:
        signature = (item["slot"], item["id"], item["key"], item["file"])
        if signature in seen_contrib:
            continue
        seen_contrib.add(signature)
        unique_contrib.append(item)

    view_tabs = [
        item
        for item in unique_contrib
        if item["slot"] == "conversation.view"
    ]
    header_contributions = [
        item
        for item in unique_contrib
        if item["slot"].startswith("conversation.session.header.")
    ]
    dock_contributions = [
        item
        for item in unique_contrib
        if item["slot"]
        in {
            "conversation.input.dock",
            "conversation.composer.dock",
            "conversation.input.overlay",
            "conversation.composer",
        }
    ]

    # Experiments are not shipped; mark rather than drop so the report is explicit.
    def mark_experimental(entries: dict[str, list[str]]) -> dict[str, list[str]]:
        out: dict[str, list[str]] = {}
        for key, files in entries.items():
            out[key] = unique_sorted(files)
        return out

    return {
        "chat_node_kinds": mark_experimental(chat_nodes),
        "toolview_keys": mark_experimental(toolviews),
        "slots": mark_experimental(slots),
        "projection_keys": sorted(projections),
        "contributions": unique_contrib,
        "view_tabs": view_tabs,
        "header_contributions": header_contributions,
        "dock_contributions": dock_contributions,
    }


def extract_ios_inventory(ios: Path) -> dict:
    probe = ios / "examples/probe-app/PhoneDSHProbe"
    models = probe / "NativeConversationModels.swift"
    tools = probe / "NativeToolCallModel.swift"
    theme = probe / "NativeChatTheme.swift"
    chat = probe / "ChatPage.swift"
    chat_model = probe / "ChatModel.swift"
    management = probe / "DSHManagementModel.swift"

    def read(path: Path) -> str:
        try:
            return path.read_text(encoding="utf-8")
        except OSError:
            return ""

    kind_text = read(models)
    kind_match = re.search(r"enum\s+Kind\s*:\s*Equatable\s*\{(.*?)\n\s*\}", kind_text, re.S)
    kind_body = kind_match.group(1) if kind_match else ""
    kinds: list[str] = []
    for line in kind_body.splitlines():
        if not line.strip().startswith("case "):
            continue
        for part in line.strip()[5:].split(","):
            name = re.match(r"\s*([a-zA-Z_][\w]*)", part)
            if name:
                kinds.append(name.group(1))
    kinds = unique_sorted(kinds)

    tool_text = read(tools)
    variant_match = re.search(r"enum\s+Variant\s*\{(.*?)\n\s*\}", tool_text, re.S)
    variant_body = variant_match.group(1) if variant_match else ""
    variants = unique_sorted(
        re.findall(r"\b([a-zA-Z_][\w]*)", variant_body.replace(",", "\n"))
    )
    variants = [v for v in variants if v not in {"case", "enum", "Variant"}]

    title_map: dict[str, str] = {}
    for match in re.finditer(r'case\s+"([^"]+)"\s*:\s*return\s+"([^"]*)"', tool_text):
        title_map[match.group(1)] = match.group(2)
    case_names = unique_sorted(re.findall(r'case\s+"([^"]+)"', tool_text))

    theme_text = read(theme)
    colors: dict[str, dict] = {}
    for match in re.finditer(
        r"static\s+let\s+(\w+)\s*=\s*color\(light:\s*0x([0-9A-Fa-f]+),\s*dark:\s*0x([0-9A-Fa-f]+)\)",
        theme_text,
    ):
        colors[match.group(1)] = {
            "light": "#" + match.group(2).upper().zfill(6),
            "dark": "#" + match.group(3).upper().zfill(6),
        }
    fonts: dict[str, float] = {}
    for match in re.finditer(
        r"static\s+func\s+(\w+)\(\)\s*->\s*Font\s*\{\s*\.system\(size:\s*([\d.]+)\)", theme_text
    ):
        fonts[match.group(1)] = float(match.group(2))

    probes = [
        ("transcript_horizontal_padding", r"\.padding\(\.horizontal,\s*(\d+(?:\.\d+)?)\)"),
        ("header_frame_height", r"\.frame\(height:\s*(\d+(?:\.\d+)?)\)"),
        ("composer_corner_radius", r"RoundedRectangle\(cornerRadius:\s*(\d+(?:\.\d+)?)"),
        ("font_17_semibold", r"\.font\(\.system\(size:\s*17,\s*weight:\s*\.semibold\)\)"),
        ("font_14_body", r"\.font\(NativeChatTheme\.bodyFont\(\)\)"),
        ("line_spacing", r"\.lineSpacing\(([^)]*)\)"),
        ("max_width_296", r"maxWidth:\s*296"),
        ("min_height_36", r"minHeight:\s*36"),
        ("max_height_336", r"maxHeight:\s*336"),
        ("enter_key_hint", r"enterKeyHint|submitLabel|onSubmit"),
        ("todo_terms", r"\btodo\b|\bTodo\b"),
        ("plan_terms", r"planMode|PlanChip|planReview|exit_plan_mode|/plan"),
        ("turn_process_terms", r"turnProcess|turn-process|turnTail|turn-tail"),
        ("trigger_terms", r"turn-trigger|turnTrigger"),
        ("inbox_terms", r"inboxSpliced|inbox"),
        ("subagent_terms", r"subagentCatalog|subagentTiming|parentSessionId"),
    ]
    probe_results: dict[str, list[dict]] = {}
    for label, pattern in probes:
        regex = re.compile(pattern)
        hits: list[dict] = []
        for name, text in (
            ("ChatPage.swift", read(chat)),
            ("ChatModel.swift", read(chat_model)),
            ("DSHManagementModel.swift", read(management)),
            ("NativeChatTheme.swift", theme_text),
        ):
            for line_no, line in enumerate(text.splitlines(), 1):
                if regex.search(line):
                    hits.append(
                        {
                            "file": name,
                            "line": line_no,
                            "text": line.strip()[:180],
                        }
                    )
        probe_results[label] = hits[:40]

    projection_mentions: dict[str, list[str]] = {}
    for key in [
        "todos",
        "plan",
        "inbox",
        "userQuestions",
        "subagentCatalog",
        "subagentTiming",
        "subagent",
        "goal",
        "title",
        "permissions",
        "tokenUsage",
        "contextPressure",
        "contextBreakdown",
        "sessionStats",
    ]:
        files: list[str] = []
        for name, text in (
            ("ChatModel.swift", read(chat_model)),
            ("DSHManagementModel.swift", read(management)),
        ):
            if re.search(rf"\b{re.escape(key)}\b", text):
                files.append(name)
        projection_mentions[key] = files

    return {
        "chat_item_kinds": kinds,
        "tool_variants": variants,
        "tool_title_cases": case_names,
        "tool_titles": title_map,
        "theme_colors": colors,
        "theme_fonts": fonts,
        "key_probes": probe_results,
        "projection_mentions": projection_mentions,
    }


# ---------------------------------------------------------------------------
# Comparison and report
# ---------------------------------------------------------------------------

NODE_MAP = {
    "user": "user",
    "steering": "user (no distinct kind)",
    "context": "context",
    "turn-trigger": None,
    "system-prompt": None,
    "assistant-step": "assistant / reasoning",
    "tool-call": "toolCall",
    "command": None,
    "command-input": None,
    "compaction": "systemEvent",
    "manual-compaction": None,
    "model-retry": "systemEvent",
    "turn-error": "turnError",
    "turn-max-tokens": "maxTokens",
    "turn-process": None,
    "turn-tail": None,
    "unknown": "unknown",
    "question-reply": None,
    "workflow-run": None,
    "submitted-plan": None,
}

IOS_SPECIAL_TOOLS = {
    "bash",
    "pwsh",
    "read",
    "read_image",
    "web_fetch",
    "web_search",
    "grep",
    "glob",
    "write",
    "edit",
    "str_replace_editor",
    "run_code",
    "todo_write",
    "ask_user_question",
    "subagent",
    "cordis_package_inspect",
    "cordis_runtime_inspect",
}

PROJECTION_STATUS = {
    "permissions": "read (refreshAccessModes)",
    "tokenUsage": "read (refreshNativeMetrics)",
    "contextPressure": "read (refreshNativeMetrics)",
    "contextBreakdown": "read (refreshNativeMetrics)",
    "sessionStats": "read (refreshNativeMetrics)",
    "plan": "read only in DSHManagementModel activity (unreachable)",
    "todos": "read only in DSHManagementModel activity (unreachable)",
    "subagentCatalog": "read only in DSHManagementModel activity (unreachable)",
    "goal": "read with wrong path values.goal.current.goal",
    "title": "read with wrong path values.title.title",
    "inbox": "not read",
    "userQuestions": "not read",
    "subagentTiming": "not read",
    "subagent": "not read",
}

# Slots that put a user-visible control on the session page. Everything else
# is a layout/child seat; it should not be reported as an audit hole.
SLOT_CLASS = {
    "conversation.chat.node": "visible",
    "conversation.chat.turnTail": "visible",
    "conversation.chat.assistant-actions": "visible",
    "conversation.chat.message.images": "visible",
    "conversation.chat.user.images": "visible",
    "conversation.chat.reasoning.body": "visible",
    "conversation.chat.reasoning.content": "visible",
    "conversation.chat.user.content": "visible",
    "conversation.composer": "visible",
    "conversation.composer.bar": "structural",
    "conversation.composer.dock": "visible",
    "conversation.content": "structural",
    "conversation.header": "structural",
    "conversation.hero.agentPreset": "visible",
    "conversation.hero.workspace": "visible",
    "conversation.hero.workspace.directoryFlow": "visible",
    "conversation.images.content": "visible",
    "conversation.input.activity": "visible",
    "conversation.input.attachments": "visible",
    "conversation.input.dock": "visible",
    "conversation.input.left": "seat-with-no-shipped-contributor",
    "conversation.input.model": "visible",
    "conversation.input.model.label": "visible",
    "conversation.input.overlay": "visible",
    "conversation.input.permission": "visible",
    "conversation.input.plan": "visible",
    "conversation.input.right": "seat-with-no-shipped-contributor",
    "conversation.plan-review.actions": "visible",
    "conversation.session": "structural",
    "conversation.session.header": "structural",
    "conversation.session.header.actions": "visible",
    "conversation.session.header.corner": "visible",
    "conversation.session.header.lineage": "visible",
    "conversation.session.header.utilities": "visible",
    "conversation.trajectory.images": "visible",
    "conversation.user.text": "structural",
    "conversation.user.text.node": "visible",
    "conversation.view": "visible",
    "conversation.chat.flow": "structural",
    "conversation.approval.detail": "visible",
}

SLOT_SYNONYMS = {
    "conversation.chat.assistant-actions": ["反馈", "feedback", "MessageIconActions"],
    "conversation.chat.reasoning.body": ["reasoning", "思考", "Thinking"],
    "conversation.chat.reasoning.content": ["reasoning", "思考", "Thinking"],
    "conversation.chat.user.content": ["用户气泡", "userBubble", "UserContent"],
    "conversation.images.content": ["图片", "image", "lightbox"],
    "conversation.input.attachments": ["附件", "attachment"],
    "conversation.input.model": ["模型", "modelMenu", "model"],
    "conversation.input.model.label": ["模型", "modelMenu", "model"],
    "conversation.input.permission": ["权限", "accessMode", "PermissionSelect"],
    "conversation.input.plan": ["计划", "PlanChip", "Plan mode"],
    "conversation.hero.agentPreset": ["agent preset", "预设", "hero"],
    "conversation.hero.workspace": ["workspace", "工作区", "hero"],
    "conversation.hero.workspace.directoryFlow": ["workspace", "工作区", "hero"],
    "conversation.session.header.actions": ["header actions", "页头", "actions"],
    "conversation.session.header.corner": ["corner", "页头"],
    "conversation.session.header.utilities": ["utilities", "页头", "header"],
    "conversation.session.header.lineage": ["lineage", "breadcrumb", "面包屑"],
    "conversation.trajectory.images": ["trajectory", "轨迹"],
    "conversation.user.text.node": ["user text", "引用", "goal command"],
    "conversation.view": ["轨迹", "trajectory", "view tab"],
}

PROJECTION_CLASS = {
    "todos": "visible",
    "plan": "visible",
    "inbox": "visible",
    "userQuestions": "visible",
    "subagentCatalog": "visible",
    "subagentTiming": "visible",
    "subagent": "visible",
    "goal": "visible",
    "title": "visible",
    "permissions": "visible",
    "tokenUsage": "visible",
    "contextPressure": "visible",
    "contextBreakdown": "visible",
    "sessionStats": "visible",
    "modelSelection": "visible",
    "agentPreset": "visible",
    "turnOutline": "visible",
    "imageLimits": "visible",
    "sessionListMetadata": "internal",
    "agentTeam": "experimental",
    "harnessDevLegacyPrompt": "internal",
    "llmRetry": "internal",
    "sandboxMode": "internal",
    "subagentModelSelectionPolicy": "experimental",
    "timeContext": "internal",
    "titleInput": "internal",
    "tmuxContext": "internal",
    "turnBoundary": "experimental",
}

PROJECTION_SYNONYMS = {
    "modelSelection": ["模型", "modelMenu", "model"],
    "agentPreset": ["agent preset", "预设", "preset"],
    "turnOutline": ["turn", "轮次", "outline"],
    "imageLimits": ["图片", "image"],
    "sessionListMetadata": ["会话列表", "session list"],
}


def report_names(audit_dir: Path) -> list[Path]:
    return sorted(audit_dir.glob("0[1-8]-*.md"))


def covered_by(item: str, reports: dict[str, str]) -> list[str]:
    return [name for name, text in reports.items() if item and item in text]


def coverage_kind(item: str, reports: dict[str, str], synonyms: list[str]) -> tuple[str, list[str]]:
    exact = covered_by(item, reports)
    if exact:
        return "exact", exact
    for synonym in synonyms:
        found = covered_by(synonym, reports)
        if found:
            return "synonym", found
    return "none", []



def build_comparison(
    official_inv: dict,
    ios_inv: dict,
    reports: dict[str, str],
) -> dict:
    chat_rows = []
    for key, files in sorted(official_inv["chat_node_kinds"].items()):
        chat_rows.append(
            {
                "key": key,
                "official_files": files,
                "reports": covered_by(key, reports),
                "ios_equivalent": NODE_MAP.get(key, "UNMAPPED"),
            }
        )

    tool_rows = []
    for key, files in sorted(official_inv["toolview_keys"].items()):
        tool_rows.append(
            {
                "key": key,
                "official_files": files,
                "reports": covered_by(key, reports),
                "ios_special": key in IOS_SPECIAL_TOOLS,
            }
        )

    slot_rows = []
    for key, files in sorted(official_inv["slots"].items()):
        kind, reports_found = coverage_kind(key, reports, SLOT_SYNONYMS.get(key, []))
        slot_rows.append(
            {
                "slot": key,
                "class": SLOT_CLASS.get(key, "unknown"),
                "coverage_kind": kind,
                "official_files": files,
                "reports": reports_found,
            }
        )

    projection_rows = []
    for key in sorted(official_inv["projection_keys"]):
        kind, reports_found = coverage_kind(
            key, reports, PROJECTION_SYNONYMS.get(key, [])
        )
        projection_rows.append(
            {
                "key": key,
                "class": PROJECTION_CLASS.get(key, "internal"),
                "coverage_kind": kind,
                "reports": reports_found,
                "ios_status": PROJECTION_STATUS.get(key, "not mapped in scanner"),
            }
        )

    audit_gaps = {
        "chat_node_kinds": [row["key"] for row in chat_rows if not row["reports"]],
        "toolview_keys": [row["key"] for row in tool_rows if not row["reports"]],
        "slots": [
            row["slot"]
            for row in slot_rows
            if row["class"] == "visible" and row["coverage_kind"] == "none"
        ],
        "projection_keys": [
            row["key"]
            for row in projection_rows
            if row["class"] == "visible" and row["coverage_kind"] == "none"
        ],
    }
    synonym_only = {
        "slots": [
            row["slot"]
            for row in slot_rows
            if row["class"] == "visible" and row["coverage_kind"] == "synonym"
        ],
        "projection_keys": [
            row["key"]
            for row in projection_rows
            if row["class"] == "visible" and row["coverage_kind"] == "synonym"
        ],
    }
    excluded = {
        "slots": [
            row["slot"]
            for row in slot_rows
            if row["class"] not in {"visible", "unknown"}
        ],
        "projection_keys": [
            row["key"]
            for row in projection_rows
            if row["class"] not in {"visible", "unknown"}
        ],
    }
    ios_generic_tools = [row["key"] for row in tool_rows if not row["ios_special"]]
    ios_missing_nodes = [
        row["key"]
        for row in chat_rows
        if row["ios_equivalent"] in (None, "UNMAPPED")
    ]

    return {
        "chat_nodes": chat_rows,
        "toolviews": tool_rows,
        "slots": slot_rows,
        "projections": projection_rows,
        "audit_gaps": audit_gaps,
        "synonym_only": synonym_only,
        "excluded": excluded,
        "ios_generic_toolviews": ios_generic_tools,
        "ios_missing_chat_nodes": ios_missing_nodes,
    }


def md_escape(value: str) -> str:
    return value.replace("|", "\\|")


def write_coverage(
    out: Path,
    official: Path,
    ios: Path,
    official_commit: str,
    tokens_light: dict[str, str],
    tokens_dark: dict[str, str],
    components: dict,
    official_inv: dict,
    ios_inv: dict,
    comparison: dict,
) -> None:
    lines: list[str] = []
    add = lines.append
    add("# iOS × 官方 DSH Session 基线扫描")
    add("")
    add(f"> 生成时间：{datetime.now(timezone.utc).isoformat(timespec='seconds')}")
    add(f"> 官方：`{official}`")
    add(f"> 官方 commit：`{official_commit}`")
    add(f"> iOS：`{ios}`")
    add("> 脚本：`scripts/ios-parity/audit.py`（静态提取，不运行 Web/iOS 工程）")
    add("")
    add("## 0. 快照")
    add("")
    add("| 项 | 数量 |")
    add("|---|---|")
    add(f"| 官方 chat node kind | {len(official_inv['chat_node_kinds'])} |")
    add(f"| 官方 toolview key | {len(official_inv['toolview_keys'])} |")
    add(f"| 官方 conversation slot | {len(official_inv['slots'])} |")
    add(f"| 官方 projection key | {len(official_inv['projection_keys'])} |")
    add(f"| 官方 surface 组件 | {len(components)} |")
    add(f"| 解析出的 light token | {len(tokens_light)} |")
    add(f"| 解析出的 dark token | {len(tokens_dark)} |")
    add(f"| iOS ChatItem.Kind | {len(ios_inv['chat_item_kinds'])} |")
    add(f"| iOS tool variant | {len(ios_inv['tool_variants'])} |")
    add("")
    add("## 1. 审计缺口（官方可见 surface 没有被 01–08 报告按名字或同义词提到）")
    add("")
    gaps = comparison["audit_gaps"]
    for group, values in gaps.items():
        add(f"### {group}")
        add("")
        if values:
            add(f"- **{len(values)}** 个可见 surface 未被报告覆盖：")
            for value in values:
                add(f"  - `{value}`")
        else:
            add("- 无（全部被至少一份轴报告按名字或同义词覆盖）")
        add("")
    add("> 说明：只统计 `visible` 类；布局/子 seat 和 experimental projection 放在 §1.1，不当作审计缺口。")
    add("")
    add("### 1.0.1 同义词覆盖（需人工确认是否真的覆盖）")
    add("")
    synonym_only = comparison.get("synonym_only", {})
    for group, values in synonym_only.items():
        add(f"#### {group}")
        add("")
        if values:
            for value in values:
                add(f"- `{value}`")
        else:
            add("- 无")
        add("")
    add("### 1.1 已排除的非可见项（供确认）")
    add("")
    excluded = comparison.get("excluded", {})
    for group, values in excluded.items():
        add(f"- **{group}**：`" + "`, `".join(values) + "`")
    add("")
    add("## 2. 官方 session surface 清单")
    add("")
    add("### 2.1 Chat node kinds")
    add("")
    add("| key | iOS 等价 | 报告覆盖 |")
    add("|---|---|---|")
    for row in comparison["chat_nodes"]:
        reports = ", ".join(row["reports"]) if row["reports"] else "**无**"
        add(
            f"| `{md_escape(row['key'])}` | {md_escape(str(row['ios_equivalent']))} | {reports} |"
        )
    add("")
    add("### 2.2 Toolview keys")
    add("")
    add("| key | iOS 专用 | 报告覆盖 |")
    add("|---|---|---|")
    for row in comparison["toolviews"]:
        reports = ", ".join(row["reports"]) if row["reports"] else "**无**"
        add(
            f"| `{md_escape(row['key'])}` | {'✅' if row['ios_special'] else 'generic'} | {reports} |"
        )
    add("")
    add(f"- iOS 专用：**{len(comparison['toolviews']) - len(comparison['ios_generic_toolviews'])}** / {len(comparison['toolviews'])}")
    add(f"- iOS 通用：**{len(comparison['ios_generic_toolviews'])}**：`" + "`, `".join(comparison["ios_generic_toolviews"]) + "`")
    add("")
    add("### 2.3 Conversation slots")
    add("")
    add("| slot | class | 覆盖 | 报告 |")
    add("|---|---|---|---|")
    for row in comparison["slots"]:
        reports = ", ".join(row["reports"]) if row["reports"] else "**无**"
        add(
            f"| `{md_escape(row['slot'])}` | {row['class']} | {row['coverage_kind']} | {reports} |"
        )
    add("")
    add("### 2.3.1 Slot 贡献者（可见控件）")
    add("")
    add("| slot | id / key / label | 文件 |")
    add("|---|---|---|")
    for item in official_inv.get("contributions", []):
        ident = item["id"] or item["key"] or item["label"] or "—"
        add(f"| `{md_escape(item['slot'])}` | `{md_escape(ident)}` | `{md_escape(item['file'])}` |")
    add("")
    add("### 2.3.2 Session 视图 tab（`conversation.view`）")
    add("")
    if official_inv.get("view_tabs"):
        for item in official_inv["view_tabs"]:
            add(f"- `{item['id'] or item['label'] or '?'}` — `{item['file']}`")
    else:
        add("- 未解析到 `conversation.view` 注册")
    add("")
    add("### 2.4 Projection keys")
    add("")
    add("| key | class | 覆盖 | iOS 现状 | 报告 |")
    add("|---|---|---|---|---|")
    for row in comparison["projections"]:
        reports = ", ".join(row["reports"]) if row["reports"] else "**无**"
        add(
            f"| `{md_escape(row['key'])}` | {row['class']} | {row['coverage_kind']} | "
            f"{md_escape(row['ios_status'])} | {reports} |"
        )
    add("")
    add("## 3. 官方组件 metrics（解析值，light / dark）")
    add("")
    add("> 只列 base rule 的关键字段；`var()` 已递归展开，`calc(px)` 已求值。")
    add("")
    for name, surface in components.items():
        if surface.get("missing"):
            add(f"### {name} — **文件缺失** `{surface['file']}`")
            add("")
            continue
        classes = surface.get("classes", {})
        if not classes:
            continue
        add(f"### {name}")
        add("")
        add(f"`{surface['file']}`")
        add("")
        add("| class | 属性 | light | dark |")
        add("|---|---|---|---|")
        for cls, data in classes.items():
            base = data["base"]
            for prop, value in base["declarations"].items():
                add(
                    f"| `.{md_escape(cls)}` | `{md_escape(prop)}` | "
                    f"`{md_escape(value['light'])}` | `{md_escape(value['dark'])}` |"
                )
        add("")
    add("## 4. iOS 当前关键探针")
    add("")
    for label, hits in ios_inv["key_probes"].items():
        add(f"### {label}")
        add("")
        if not hits:
            add("- 0 命中")
        else:
            for hit in hits:
                add(f"- `{hit['file']}:{hit['line']}` — `{md_escape(hit['text'])}`")
        add("")
    add("## 5. iOS theme token")
    add("")
    add("| name | light | dark |")
    add("|---|---|---|")
    for name, value in ios_inv["theme_colors"].items():
        add(f"| `{name}` | `{value['light']}` | `{value['dark']}` |")
    add("")
    add("字体：" + ", ".join(f"`{k}={v:g}`" for k, v in ios_inv["theme_fonts"].items()))
    add("")
    add("## 6. 建议人工复核")
    add("")
    add("1. 优先看 §1 的“未被报告提到”清单；把真实漏项补进对应轴报告。")
    add("2. 看 §2.2 的 generic toolview 清单；确认是否有高价值 key 需要专用卡。")
    add("3. 看 §2.4 的 projection：`todos/plan/subagentCatalog` 已能读但只在不可达活动页；`inbox/userQuestions` 未读。")
    add("4. 对照 §3 的 base metrics 与 iOS 探针，确认 master §6 的数值没有被实现漂移。")
    add("5. 官方 402pt 截图仍然缺失；本脚本不能替代 golden 截图。")
    add("")
    out.write_text("\n".join(lines) + "\n", encoding="utf-8")


def git_head(path: Path) -> str:
    try:
        return subprocess.check_output(
            ["git", "-C", str(path), "rev-parse", "HEAD"], text=True, stderr=subprocess.DEVNULL
        ).strip()
    except Exception:
        return "unknown"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--official", type=Path, default=DEFAULT_OFFICIAL)
    parser.add_argument(
        "--ios",
        type=Path,
        default=Path(__file__).resolve().parents[2],
    )
    parser.add_argument(
        "--out",
        type=Path,
        default=None,
        help="output directory (default: <ios>/docs/receipts/ios-session-audit/parity)",
    )
    args = parser.parse_args()

    official = args.official.resolve()
    ios = args.ios.resolve()
    out = (args.out or (ios / "docs/receipts/ios-session-audit/parity")).resolve()
    out.mkdir(parents=True, exist_ok=True)

    if not (official / "packages/client/ui-theme").is_dir():
        print(f"official checkout not found or incomplete: {official}", file=sys.stderr)
        return 2

    tokens_light: dict[str, str] = {}
    tokens_dark: dict[str, str] = {}
    theme_root = official / "packages/client/ui-theme/src/styles"
    for filename in ("base.css", "design-platform.css", "gradient-shadow-text.css", "corner-shape.css"):
        load_css_tokens(theme_root / filename, tokens_light, tokens_dark)
    # Two body blocks in design-platform.css: the later block wins per theme.
    for key, value in list(tokens_light.items()):
        tokens_light[key] = resolve_value(value, tokens_light)
    for key, value in list(tokens_dark.items()):
        tokens_dark[key] = resolve_value(value, tokens_dark)

    components = extract_components(official, tokens_light, tokens_dark)
    official_inv = extract_official_inventory(official)
    ios_inv = extract_ios_inventory(ios)
    reports = {
        path.name: path.read_text(encoding="utf-8")
        for path in report_names(ios / "docs/receipts/ios-session-audit")
    }
    comparison = build_comparison(official_inv, ios_inv, reports)

    (out / "official-tokens.json").write_text(
        json.dumps(
            {
                "light": {k: v for k, v in sorted(tokens_light.items())},
                "dark": {k: v for k, v in sorted(tokens_dark.items())},
            },
            indent=2,
        ),
        encoding="utf-8",
    )
    (out / "official-components.json").write_text(
        json.dumps(components, indent=2, ensure_ascii=False), encoding="utf-8"
    )
    (out / "official-inventory.json").write_text(
        json.dumps(official_inv, indent=2, ensure_ascii=False), encoding="utf-8"
    )
    (out / "ios-inventory.json").write_text(
        json.dumps(ios_inv, indent=2, ensure_ascii=False), encoding="utf-8"
    )
    (out / "comparison.json").write_text(
        json.dumps(comparison, indent=2, ensure_ascii=False), encoding="utf-8"
    )

    summary = {
        "generated_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "official": str(official),
        "official_commit": git_head(official),
        "ios": str(ios),
        "ios_head": git_head(ios),
        "counts": {
            "official_chat_nodes": len(official_inv["chat_node_kinds"]),
            "official_toolviews": len(official_inv["toolview_keys"]),
            "official_slots": len(official_inv["slots"]),
            "official_projections": len(official_inv["projection_keys"]),
            "official_surfaces": len(components),
            "light_tokens": len(tokens_light),
            "dark_tokens": len(tokens_dark),
            "ios_chat_item_kinds": len(ios_inv["chat_item_kinds"]),
            "ios_tool_variants": len(ios_inv["tool_variants"]),
        },
        "audit_gaps": comparison["audit_gaps"],
        "synonym_only": comparison.get("synonym_only", {}),
        "ios_generic_toolviews": comparison["ios_generic_toolviews"],
        "ios_missing_chat_nodes": comparison["ios_missing_chat_nodes"],
    }
    (out / "summary.json").write_text(
        json.dumps(summary, indent=2, ensure_ascii=False), encoding="utf-8"
    )
    write_coverage(
        out / "coverage.md",
        official,
        ios,
        summary["official_commit"],
        tokens_light,
        tokens_dark,
        components,
        official_inv,
        ios_inv,
        comparison,
    )

    print(f"wrote {out}")
    print(json.dumps(summary["counts"], indent=2))
    print("audit gaps:", {k: len(v) for k, v in comparison["audit_gaps"].items()})
    print("iOS generic toolviews:", len(comparison["ios_generic_toolviews"]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
