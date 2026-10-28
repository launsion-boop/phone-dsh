# SPDX-License-Identifier: MIT
"""Markdown rendering."""


def to_markdown(summary):
    return (
        "# Reading report\n\n"
        "| metric | value |\n"
        "| --- | --- |\n"
        "| total minutes | %s |\n" % summary["total_minutes"]
        + "| users | %s |\n" % summary["users"]
        + "| titles | %s |\n" % summary["titles"]
        + "| average minutes | %.1f |\n" % summary["average_minutes"]
    )
