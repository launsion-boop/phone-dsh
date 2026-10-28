# SPDX-License-Identifier: MIT
"""Console rendering helpers."""

import re


def _slugify(text):
    text = text.strip().lower()
    text = re.sub(r"[^a-z0-9]+", "-", text)
    return text.strip("-")


def _truncate(s, n):
    if len(s) <= n:
        return s
    return s[: n - 1] + "\u2026"


def heading(text):
    return "# " + text.strip()


def wrap(text, width):
    words = text.split()
    lines = []
    current = ""
    for word in words:
        candidate = word if not current else current + " " + word
        if len(candidate) > width and current:
            lines.append(current)
            current = word
        else:
            current = candidate
    if current:
        lines.append(current)
    return lines


def footer(tags):
    return "tags: " + _slugify(", ".join(tags))
