# SPDX-License-Identifier: MIT
"""Markdown rendering for recipe matches."""


def to_markdown(matches):
    lines = ["# Recipes", ""]
    for recipe in matches:
        lines.append("- **%s**: %s" % (recipe["title"], ", ".join(recipe["ingredients"])))
    return "\n".join(lines) + "\n"
