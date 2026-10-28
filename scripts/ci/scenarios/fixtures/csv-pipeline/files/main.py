# SPDX-License-Identifier: MIT
"""CSV cleaning entry point: read, validate, normalize, report."""

import argparse

from loader import read_csv
from report import write_report
from transform import normalize_rows
from validate import check_rows


def run(input_path, out_path):
    rows = read_csv(input_path)
    check_rows(rows)
    normalized = normalize_rows(rows)
    write_report(out_path, normalized)
    return normalized


def main(argv=None):
    parser = argparse.ArgumentParser(prog="csv-pipeline")
    parser.add_argument("--input", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args(argv)
    rows = run(args.input, args.out)
    print("wrote %d row(s)" % len(rows))


if __name__ == "__main__":
    main()
