# SPDX-License-Identifier: MIT
"""Print a summary and per-row Fahrenheit values."""

import sys

import parser
import report


def main(argv):
    path = argv[1] if len(argv) > 1 else "sample.log"
    with open(path, encoding="utf-8") as handle:
        rows = [parser.parse_line(line) for line in handle if line.strip()]
    print(report.summary(rows))
    for row in rows:
        print(row["ts"], round(report.to_fahrenheit(row["temp"]), 1))


if __name__ == "__main__":
    main(sys.argv)
