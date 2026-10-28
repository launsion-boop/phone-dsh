# SPDX-License-Identifier: MIT
"""Command-line rendering for one note."""

import format


def render(note, width):
    lines = []
    title = note.get("title", "") if isinstance(note, dict) else note.title
    body = note.get("body", "") if isinstance(note, dict) else note.body
    created = note.get("created", "") if isinstance(note, dict) else note.created
    tags = note.get("tags", []) if isinstance(note, dict) else []
    lines.append("#" * width)
    lines.append("")
    lines.append(format.heading(title))
    if created:
        lines.append("created: " + created)
    lines.append("")
    for paragraph in body.split("\n\n"):
        wrapped = format.wrap(paragraph, width)
        lines.extend(wrapped)
        lines.append("")
    lines.append(format.footer(tags))
    lines.append("#" * width)
    return "\n".join(lines)
