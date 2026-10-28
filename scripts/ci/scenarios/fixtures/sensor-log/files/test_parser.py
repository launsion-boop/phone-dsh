# SPDX-License-Identifier: MIT
import unittest

import parser

LINE = "2026-10-24T08:00:00,temp=21.5,hum=48"


class ParserTests(unittest.TestCase):
    def test_parse_timestamp(self):
        self.assertEqual(parser.parse_line(LINE)["ts"], "2026-10-24T08:00:00")

    def test_parse_numeric_fields(self):
        row = parser.parse_line(LINE)
        self.assertEqual(row["temp"], 21.5)
        self.assertEqual(row["hum"], 48.0)

    def test_parse_rejects_missing_equals(self):
        with self.assertRaises(ValueError):
            parser.parse_line("2026-10-24T08:00:00")

    def test_parse_rejects_blank(self):
        with self.assertRaises(ValueError):
            parser.parse_line("")


if __name__ == "__main__":
    unittest.main()
