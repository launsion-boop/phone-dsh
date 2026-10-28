# SPDX-License-Identifier: MIT
import unittest

from textstats import count_words, top_words


class TextStatsTests(unittest.TestCase):
    def test_count_words_basic(self):
        self.assertEqual(count_words("apple banana apple"),
                         {"apple": 2, "banana": 1})

    def test_count_words_strips_edge_punctuation(self):
        self.assertEqual(count_words("apple, banana!"),
                         {"apple": 1, "banana": 1})

    def test_top_words_order(self):
        self.assertEqual(top_words("pear pear apple", 2),
                         [("pear", 2), ("apple", 1)])

    def test_top_words_ties_alphabetical(self):
        self.assertEqual(top_words("kiwi apple mango", 3),
                         [("apple", 1), ("kiwi", 1), ("mango", 1)])

    def test_top_words_truncates(self):
        self.assertEqual(len(top_words("kiwi apple mango", 2)), 2)


if __name__ == "__main__":
    unittest.main()
