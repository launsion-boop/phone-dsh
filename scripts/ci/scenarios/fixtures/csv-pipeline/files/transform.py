# SPDX-License-Identifier: MIT
"""Normalize string cells."""


def normalize_rows(rows):
    normalized = []
    for row in rows:
        normalized.append({key: value.strip().lower() for key, value in row.items()})
    return normalized
