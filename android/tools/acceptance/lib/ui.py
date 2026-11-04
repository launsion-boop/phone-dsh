#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Query one `uiautomator dump` XML file; no device access, no state.

`run-product-flow.sh` drives the product with taps and dumps. Compose does not
publish `resource-id`s in this App (no `testTagsAsResourceId`), so every
selector is a text or content-description match. Keeping the XML parsing here
(instead of inline `grep`) is what makes a selector a decision with one rule:
"the node whose text is exactly this" or "the EditText directly under this
label", rather than a byte pattern that happens to match.

Subcommands (all print one line unless noted):

  find    --text T [--exact] [--nth N]      `cx cy` of the matching node
  count   --regex R [--field text|desc|any] number of matching nodes
  longest --contains S                      `<length>\t<text>` of the longest
                                            text node containing S, or `0\t`
  field-under --label L [--max-gap PX]      `cx cy` of the EditText whose top
                                            edge is at or below L's bottom edge
  drag-gap [--ymin N] [--ymax N]            `cx cy` inside the largest vertical
                                            gap between text fields/buttons: the
                                            point a scroll gesture must start from
  texts   [--limit N]                       every non-empty node, one per line:
                                            `text<TAB>desc<TAB>bounds<TAB>class`
  has     --text T [--exact]                exit 0 when found, 1 otherwise

A node's `bounds` is `[l,t][r,b]`; a zero-area bounds (Compose reports
`[0,0][0,0]` for a node scrolled out of the viewport) is never matched: tapping
the centre of such a node would tap the top-left corner of the screen.
"""

from __future__ import annotations

import argparse
import re
import sys
import xml.etree.ElementTree as ET

BOUNDS_RE = re.compile(r"^\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]$")
EDIT_TEXT = "android.widget.EditText"


def load(path: str):
    try:
        return ET.parse(path).getroot()
    except (OSError, ET.ParseError):
        return None


def bounds(node):
    match = BOUNDS_RE.match(node.get("bounds") or "")
    if match is None:
        return None
    return tuple(int(part) for part in match.groups())


def visible(rect) -> bool:
    return rect is not None and rect[2] > rect[0] and rect[3] > rect[1]


def center(rect) -> tuple[int, int]:
    return ((rect[0] + rect[2]) // 2, (rect[1] + rect[3]) // 2)


def values(node):
    return ((node.get("text") or ""), (node.get("content-desc") or ""))


def node_matches(node, needle: str, exact: bool) -> bool:
    text, desc = values(node)
    candidates = (text.strip(), desc.strip()) if not exact else (text, desc)
    if exact:
        return needle in candidates
    return needle in text or needle in desc


def emitted(rect):
    cx, cy = center(rect)
    print(f"{cx} {cy}")
    return 0


def cmd_find(args) -> int:
    root = load(args.xml)
    if root is None:
        return 1
    hits = []
    for node in root.iter("node"):
        if not node_matches(node, args.text, args.exact):
            continue
        rect = bounds(node)
        if not visible(rect):
            continue
        hits.append(rect)
    if not hits:
        return 1
    index = args.nth if args.nth >= 0 else len(hits) + args.nth
    if index < 0 or index >= len(hits):
        return 1
    return emitted(hits[index])


def cmd_count(args) -> int:
    root = load(args.xml)
    if root is None:
        return 1
    pattern = re.compile(args.regex)
    total = 0
    for node in root.iter("node"):
        text, desc = values(node)
        fields = (text,) if args.field == "text" else (desc,) if args.field == "desc" else (text, desc)
        if any(pattern.search(value) for value in fields):
            total += 1
    print(total)
    return 0


def cmd_longest(args) -> int:
    root = load(args.xml)
    if root is None:
        return 1
    best = ""
    for node in root.iter("node"):
        text, _ = values(node)
        if args.contains in text and len(text) > len(best):
            best = text
    print(f"{len(best)}\t{best}")
    return 0


def cmd_field_under(args) -> int:
    root = load(args.xml)
    if root is None:
        return 1
    label_rect = None
    for node in root.iter("node"):
        text, desc = values(node)
        if text.strip() == args.label or desc.strip() == args.label:
            rect = bounds(node)
            if visible(rect):
                label_rect = rect
                break
    if label_rect is None:
        return 1
    candidates = []
    for node in root.iter("node"):
        if (node.get("class") or "") != EDIT_TEXT:
            continue
        rect = bounds(node)
        if not visible(rect):
            continue
        gap = rect[1] - label_rect[3]
        if 0 <= gap <= args.max_gap:
            candidates.append((gap, rect))
    if not candidates:
        return 1
    candidates.sort(key=lambda item: item[0])
    return emitted(candidates[0][1])


def cmd_drag_gap(args) -> int:
    """A point in the largest vertical gap the page's interactive nodes leave.

    A drag that starts on a text field is text selection and a drag that starts
    on a button is a press; dragging the *gap between* two rows is the only
    gesture the page's own scroll sees. The gaps are measured against every
    EditText/Button on screen, so this holds for any form, not one layout.
    """
    root = load(args.xml)
    if root is None:
        return 1
    covered = []
    for node in root.iter("node"):
        if (node.get("class") or "") not in (EDIT_TEXT, "android.widget.Button"):
            continue
        rect = bounds(node)
        if visible(rect):
            covered.append((rect[1], rect[3]))
    covered.sort()
    merged = []
    for top, bottom in covered:
        if merged and top <= merged[-1][1]:
            merged[-1][1] = max(merged[-1][1], bottom)
        else:
            merged.append([top, bottom])
    gaps = []
    cursor = args.ymin
    for top, bottom in merged:
        if bottom < args.ymin or top > args.ymax:
            continue
        if top > cursor:
            gaps.append((cursor, min(top, args.ymax)))
        cursor = max(cursor, bottom)
    if cursor < args.ymax:
        gaps.append((cursor, args.ymax))
    gaps = [gap for gap in gaps if gap[1] - gap[0] >= 80]
    if not gaps:
        return 1
    widest = max(gaps, key=lambda gap: gap[1] - gap[0])
    print(f"{args.x} {(widest[0] + widest[1]) // 2}")
    return 0


def cmd_texts(args) -> int:
    root = load(args.xml)
    if root is None:
        return 1
    shown = 0
    for node in root.iter("node"):
        text, desc = values(node)
        if not text.strip() and not desc.strip():
            continue
        print(
            "{}\t{}\t{}\t{}".format(
                text.replace("\n", "\\n"),
                desc.replace("\n", "\\n"),
                node.get("bounds") or "",
                node.get("class") or "",
            )
        )
        shown += 1
        if args.limit and shown >= args.limit:
            break
    return 0


def cmd_has(args) -> int:
    root = load(args.xml)
    if root is None:
        return 1
    for node in root.iter("node"):
        if node_matches(node, args.text, args.exact):
            return 0
    return 1


def main(argv) -> int:
    parser = argparse.ArgumentParser(description="query a uiautomator dump")
    sub = parser.add_subparsers(dest="command", required=True)

    find = sub.add_parser("find")
    find.add_argument("xml")
    find.add_argument("--text", required=True)
    find.add_argument("--exact", action="store_true")
    find.add_argument("--nth", type=int, default=0)
    find.set_defaults(run=cmd_find)

    count = sub.add_parser("count")
    count.add_argument("xml")
    count.add_argument("--regex", required=True)
    count.add_argument("--field", choices=("text", "desc", "any"), default="any")
    count.set_defaults(run=cmd_count)

    longest = sub.add_parser("longest")
    longest.add_argument("xml")
    longest.add_argument("--contains", required=True)
    longest.set_defaults(run=cmd_longest)

    under = sub.add_parser("field-under")
    under.add_argument("xml")
    under.add_argument("--label", required=True)
    under.add_argument("--max-gap", type=int, default=120)
    under.set_defaults(run=cmd_field_under)

    gap = sub.add_parser("drag-gap")
    gap.add_argument("xml")
    gap.add_argument("--ymin", type=int, default=600)
    gap.add_argument("--ymax", type=int, default=1500)
    gap.add_argument("--x", type=int, default=540)
    gap.set_defaults(run=cmd_drag_gap)

    texts = sub.add_parser("texts")
    texts.add_argument("xml")
    texts.add_argument("--limit", type=int, default=0)
    texts.set_defaults(run=cmd_texts)

    has = sub.add_parser("has")
    has.add_argument("xml")
    has.add_argument("--text", required=True)
    has.add_argument("--exact", action="store_true")
    has.set_defaults(run=cmd_has)

    args = parser.parse_args(argv)
    return args.run(args)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
