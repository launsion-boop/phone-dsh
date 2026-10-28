# SPDX-License-Identifier: MIT
import os
import tempfile
import unittest

from config import REQUIRED_COLUMNS
from errors import ValidationError
from loader import read_csv
from transform import normalize_rows
from validate import check_rows


class PipelineTests(unittest.TestCase):
    def test_read_csv_returns_dicts(self):
        rows = read_csv("sample.csv")
        self.assertEqual(len(rows), 3)
        self.assertEqual(set(rows[0]), set(REQUIRED_COLUMNS))

    def test_validate_accepts_valid_rows(self):
        self.assertTrue(check_rows(read_csv("sample.csv")))

    def test_validate_rejects_missing_email(self):
        with self.assertRaises(ValidationError):
            check_rows([{"name": "nobody", "email": ""}])

    def test_normalize_strips_and_lowercases(self):
        rows = normalize_rows([{"name": " Ada ", "email": "A@B "}])
        self.assertEqual(rows, [{"name": "ada", "email": "a@b"}])

    def test_normalize_is_not_in_place(self):
        source = [{"name": " Ada ", "email": "x"}]
        normalize_rows(source)
        self.assertEqual(source[0]["name"], " Ada ")

    def test_write_report_lists_rows(self):
        from report import write_report
        handle, path = tempfile.mkstemp(suffix=".md")
        os.close(handle)
        try:
            write_report(path, [{"name": "ada", "email": "a@b"}])
            with open(path, encoding="utf-8") as reader:
                text = reader.read()
            self.assertIn("| name | email |", text)
            self.assertIn("| ada | a@b |", text)
        finally:
            os.unlink(path)


if __name__ == "__main__":
    unittest.main()
