# SPDX-License-Identifier: MIT
"""Note model and basic operations."""

from dataclasses import dataclass


@dataclass
class Note:
    title: str
    body: str
    created: str = ""


def new_note(title, body, created=""):
    return Note(title=title.strip(), body=body, created=created)
