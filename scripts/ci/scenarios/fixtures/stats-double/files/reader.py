# SPDX-License-Identifier: MIT
"""Read one JSON event per line."""

import json


def read_events(path):
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            yield json.loads(line)
