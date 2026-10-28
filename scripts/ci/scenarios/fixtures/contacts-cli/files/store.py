# SPDX-License-Identifier: MIT
"""JSON-backed contact storage. Contacts are plain dicts."""

import json


def load(path):
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def save(path, contacts):
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(contacts, handle, ensure_ascii=False, indent=2)
        handle.write("\n")
