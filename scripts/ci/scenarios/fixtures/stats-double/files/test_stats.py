# SPDX-License-Identifier: MIT
import unittest

import stats

ROWS = [
    {"user": "ada", "minutes": 30, "title": "deep work"},
    {"user": "grace", "minutes": 20, "title": "deep work"},
    {"user": "ada", "minutes": 45, "title": "refactoring"},
]


class StatsTests(unittest.TestCase):
    def test_total_minutes(self):
        self.assertEqual(stats.summarize(ROWS)["total_minutes"], 95)

    def test_users(self):
        self.assertEqual(stats.summarize(ROWS)["users"], 2)

    def test_average_minutes(self):
        self.assertEqual(stats.summarize(ROWS)["average_minutes"], 47.5)

    def test_top_items_ties_alphabetical(self):
        self.assertEqual(stats.top_items(ROWS, 2),
                         [("deep work", 2), ("refactoring", 1)])


if __name__ == "__main__":
    unittest.main()
