# SPDX-License-Identifier: MIT
"""JSON storage and lookup for notes."""

import json
import re


def _slugify(text):
    text = text.strip().lower()
    text = re.sub(r"[^a-z0-9]+", "-", text)
    return text.strip("-")


def _truncate(s, n):
    if len(s) <= n:
        return s
    return s[: n - 1] + "\u2026"


def load(path):
    with open(path, encoding="utf-8") as handle:
        raw = json.load(handle)
    return raw


def save(path, notes):
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(notes, handle, ensure_ascii=False, indent=2)
        handle.write("\n")


def find(notes, query):
    slug = _slugify(query)
    matches = []
    for note in notes:
        if slug in _slugify(note["title"]) or slug in _slugify(note["body"]):
            matches.append(note)
    return matches


def preview(note, width=40):
    return _truncate(note["body"].replace("\n", " "), width)
