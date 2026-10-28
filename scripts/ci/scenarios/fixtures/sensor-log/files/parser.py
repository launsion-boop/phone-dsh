# SPDX-License-Identifier: MIT
"""Parse one sensor log line."""


def parse_line(line):
    line = line.strip()
    if not line:
        raise ValueError("empty sensor line")
    fields = {}
    for part in line.split(","):
        key, value = part.split("=")
        fields[key] = value
    return {
        "ts": fields["ts"],
        "temp": float(fields["temp"]),
        "hum": float(fields["hum"]),
    }
