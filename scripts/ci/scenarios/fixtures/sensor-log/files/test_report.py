# SPDX-License-Identifier: MIT
import unittest

import report

ROWS = [
    {"temp": 20.0, "hum": 50.0},
    {"temp": 24.0, "hum": 40.0},
]


class ReportTests(unittest.TestCase):
    def test_summary_min_max(self):
        result = report.summary(ROWS)
        self.assertEqual(result["temp_min"], 20.0)
        self.assertEqual(result["temp_max"], 24.0)
        self.assertEqual(result["hum_min"], 40.0)

    def test_summary_averages(self):
        result = report.summary(ROWS)
        self.assertEqual(result["temp_avg"], 22.0)
        self.assertEqual(result["hum_avg"], 45.0)

    def test_boiling_point_in_fahrenheit(self):
        self.assertEqual(report.to_fahrenheit(100.0), 212.0)


if __name__ == "__main__":
    unittest.main()
