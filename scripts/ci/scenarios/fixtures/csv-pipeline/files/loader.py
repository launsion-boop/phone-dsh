# SPDX-License-Identifier: MIT
"""Read a header CSV into dictionaries."""


def _split_row(line):
    return [cell.strip() for cell in line.rstrip("\n").split(",")]


def read_csv(path):
    with open(path, encoding="utf-8") as handle:
        lines = [line for line in handle if line.strip()]
    if not lines:
        return []
    header = _split_row(lines[0])
    rows = []
    for line in lines[1:]:
        values = _split_row(line)
        rows.append(dict(zip(header, values)))
    return rows
