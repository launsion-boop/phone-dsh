# SPDX-License-Identifier: MIT
"""Pantry loading."""

import json


def load_pantry(path):
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)
